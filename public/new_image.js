var role_classes;

function updateRoleClasses(environment) {
    $('#role_class').empty().append(new Option());
    for (c in role_classes[environment].sort()) {
        $('#role_class').append(
            new Option(
                role_classes[environment][c],
                role_classes[environment][c]
            )
        );
    }
}
            
$(document).ready(function() {
    $.ajax({
        url: "/role_classes"
    }).then(function(data) {
        role_classes = jQuery.parseJSON(data)
        $('#environment').empty()
        for (environment in role_classes) {
           $('#environment').append(new Option(environment, environment));
        }
        $('#environment').on('change', function (e) {
            var optionSelected = $("option:selected", this);
            var valueSelected = this.value;
            updateRoleClasses(valueSelected);
        });
        
        // if we have a production environment, select it and populate the 
        // relevant list of clases
        if ("production" in role_classes) {
            $('#environment').val("production");
            updateRoleClasses("production");
        }
        
        // read cookie for default prefix value
        $('#prefix').val(Cookies.get('prefix'));
        
        // use a cookie to save the latest value of prefix field
        $('#prefix').on('input', function (e) {
            Cookies.set('prefix', this.value);
        });

    });

    // validate the form using jquery-validate
    $("#form").validate();

});